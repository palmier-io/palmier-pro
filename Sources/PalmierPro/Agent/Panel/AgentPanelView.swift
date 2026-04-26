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
            GlassEffectContainer {
                ZStack(alignment: .top) {
                    messageList
                    floatingTabBar
                }
            }
            footer
        }
        .background(AppTheme.Background.surfaceColor)
    }

    private var floatingTabBar: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
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
        .padding(.vertical, AppTheme.Spacing.xs)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.top, AppTheme.Spacing.xs)
    }

    private var newTabButton: some View {
        Button { service.newChat() } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("New chat")
    }

    @State private var showHistory = false

    private var historyButton: some View {
        Button { showHistory.toggle() } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 20, height: 20)
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
            HStack(spacing: 4) {
                Text(service.model.displayName)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var apiKeyButton: some View {
        ApiKeyField(
            label: "anthropic",
            placeholder: "Paste Anthropic API key (sk-ant-…)",
            hasKey: service.hasApiKey,
            maskedKey: service.maskedApiKey,
            onSave: { service.setApiKey($0) },
            onDelete: { service.removeApiKey() }
        )
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
                VStack(spacing: 8) {
                    emptyState
                    if let err = service.streamError {
                        Text(err)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 16)
            } else {
                scrollingMessages
            }
        }
    }

    private var scrollingMessages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
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
                .padding(.horizontal, 16)
                .padding(.top, Layout.panelHeaderHeight + AppTheme.Spacing.sm)
                .padding(.bottom, 8)
                .frame(maxWidth: Layout.chatColumnMax)
                .frame(maxWidth: .infinity)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onChange(of: service.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: service.isStreaming) { _, _ in scrollToBottom(proxy) }
        }
    }

    private var emptyState: some View {
        Text(service.hasApiKey ? "Hi, how can I help you with videos today?" : "Add an Anthropic API key to start")
            .font(.system(size: AppTheme.FontSize.md, weight: .medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .multilineTextAlignment(.center)
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
            apiKeyButton
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 4)
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
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Text(displayTitle)
                        .font(.system(size: AppTheme.FontSize.xs, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor)
                        .lineLimit(1)
                        .fixedSize()
                    if hovering || isActive {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                                .frame(width: 12, height: 12)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                    }
                }
                Rectangle()
                    .fill(isActive ? AppTheme.Text.primaryColor : Color.clear)
                    .frame(height: 1.5)
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
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
