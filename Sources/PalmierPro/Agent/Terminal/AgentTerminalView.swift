import AppKit
import SwiftTerm
import SwiftUI

/// The Agent Panel: a real Claude Code terminal docked in the editor. It runs the
/// interactive `claude` CLI in a PTY, wired to Palmier's MCP server so it edits
/// the open project's timeline.
struct AgentTerminalPanel: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        VStack(spacing: 0) {
            header
            AgentTerminalView(editor: editor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppTheme.Background.surfaceColor)
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Claude Code")
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            Button { editor.agentService.restartTerminal?() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("New session")
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(height: Layout.panelHeaderHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.Border.subtleColor)
                .frame(height: AppTheme.BorderWidth.hairline)
        }
    }
}

private struct AgentTerminalView: NSViewRepresentable {
    let editor: EditorViewModel

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        context.coordinator.attach(term)
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @MainActor LocalProcessTerminalViewDelegate {
        private let editor: EditorViewModel
        private weak var term: LocalProcessTerminalView?
        private var running = false
        private var restartRequested = false

        init(editor: EditorViewModel) { self.editor = editor }

        func attach(_ term: LocalProcessTerminalView) {
            self.term = term
            term.processDelegate = self
            term.nativeBackgroundColor = NSColor(AppTheme.Background.surfaceColor)
            term.nativeForegroundColor = NSColor(AppTheme.Text.primaryColor)

            let service = editor.agentService
            service.terminalTyper = { [weak term] text in term?.send(txt: text) }
            service.restartTerminal = { [weak self] in self?.restart() }

            startIfNeeded()
        }

        private func startIfNeeded() {
            guard !running, let term else { return }
            AppState.shared.startMCPService()
            let projectURL = editor.projectURL
            let model = editor.agentService.model.rawValue
            Task { @MainActor in
                let path = await Task.detached(priority: .userInitiated) { ClaudeCodeLocator.find() }.value
                guard let path else {
                    term.feed(text: "\r\n  Claude Code was not found on this Mac.\r\n  Install it from https://docs.claude.com/en/docs/claude-code, then click New session.\r\n")
                    return
                }
                guard !self.running else { return }
                self.running = true
                term.startProcess(
                    executable: path,
                    args: ClaudeCodeTerminalCommand.arguments(model: model),
                    environment: ClaudeCodeTerminalCommand.environment(claudePath: path),
                    execName: nil,
                    currentDirectory: ClaudeCodeTerminalCommand.workingDirectory(for: projectURL).path
                )
            }
        }

        private func restart() {
            guard let term else { return }
            if running {
                // Ask claude to exit (Ctrl-D); processTerminated then relaunches.
                restartRequested = true
                term.send(txt: "\u{4}")
            } else {
                startIfNeeded()
            }
        }

        // MARK: LocalProcessTerminalViewDelegate

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            running = false
            if restartRequested {
                restartRequested = false
                startIfNeeded()
            } else {
                let suffix = exitCode.map { " (code \($0))" } ?? ""
                term?.feed(text: "\r\n  Claude Code exited\(suffix). Click New session to start again.\r\n")
            }
        }
    }
}
