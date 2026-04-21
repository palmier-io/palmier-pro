import SwiftUI

struct AgentPanelView: View {
    @Environment(EditorViewModel.self) var editor

    @State private var draft = ""
    @State private var mentions: [AgentMention] = []

    private var service: AgentService { editor.agentService }

    private var canSend: Bool {
        !service.isStreaming &&
        service.hasApiKey &&
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            footer
        }
        .background(AppTheme.Background.surfaceColor)
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: 5) {
                Image(systemName: "apple.intelligence")
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.aiGradient)
                Text("Agent")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            Spacer()
            newChatButton
            historyButton
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: Layout.panelHeaderHeight)
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

    private var newChatButton: some View {
        Button { service.newChat() } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help("New chat")
    }

    @State private var showHistory = false

    private var historyButton: some View {
        Button { showHistory.toggle() } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help("Chat history")
        .popover(isPresented: $showHistory, arrowEdge: .top) {
            ChatHistoryList(
                sessions: service.sessions,
                currentId: service.currentSessionId,
                onSelect: { id in
                    service.selectSession(id)
                    showHistory = false
                },
                onDelete: { service.deleteSession($0) }
            )
        }
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
                VStack(alignment: .leading, spacing: 18) {
                    let results = toolResults
                    ForEach(service.messages) { msg in
                        AgentMessageView(message: msg, toolResults: results)
                            .id(msg.id)
                    }
                    if service.isStreaming {
                        thinkingChip.id("streaming-indicator")
                    }
                    if let err = service.streamError {
                        Text(err)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(.red)
                            .padding(.top, AppTheme.Spacing.sm)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onChange(of: service.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: service.isStreaming) { _, _ in scrollToBottom(proxy) }
        }
    }

    private var thinkingChip: some View {
        ThinkingDots()
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
        AgentInputBox(
            draft: $draft,
            mentions: $mentions,
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
    }

    private func submit() {
        guard canSend else { return }
        service.send(text: draft, mentions: mentions)
        draft = ""
        mentions.removeAll()
    }
}
