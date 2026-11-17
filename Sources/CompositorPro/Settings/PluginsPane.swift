import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Installed agent plugins. Tools run out of process, so the trust decision is explicit here and
/// an untrusted or tampered bundle is refused by the executor until the user changes it.
struct PluginsPane: View {
    @State private var plugins: [InstalledPlugin] = []
    @State private var status: String?
    @State private var isBusy = false

    private let store = PluginStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: L10n.string("Plugins")) {
                Text(L10n.string("Plugins add read-only tools that agents can call. Each tool runs as a separate process; a bundle whose files change after install is blocked."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                if plugins.isEmpty {
                    Text(L10n.string("No plugins installed."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                } else {
                    ForEach(plugins, id: \.manifest.id) { plugin in
                        pluginRow(plugin)
                    }
                }

                HStack(spacing: AppTheme.Spacing.md) {
                    Button(L10n.string("Install Plugin…")) { install() }
                        .buttonStyle(.capsule(.secondary))
                        .disabled(isBusy)
                    Button(L10n.string("Reload")) { Task { await reload() } }
                        .buttonStyle(.capsule(.secondary))
                        .disabled(isBusy)
                    Spacer(minLength: 0)
                }

                if let status {
                    Text(verbatim: status)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await reload() }
    }

    private func pluginRow(_ plugin: InstalledPlugin) -> some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(verbatim: "\(plugin.manifest.name) \(plugin.manifest.version)")
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(verbatim: plugin.manifest.toolName)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            Spacer(minLength: AppTheme.Spacing.lg)

            Picker(String(), selection: trustBinding(for: plugin)) {
                Text(L10n.string("Trusted")).tag(PluginTrustLevel.trusted)
                Text(L10n.string("Untrusted")).tag(PluginTrustLevel.untrusted)
                Text(L10n.string("Blocked")).tag(PluginTrustLevel.blocked)
            }
            .labelsHidden()
            .fixedSize()
            .disabled(isBusy || plugin.trust == .blocked)
            .accessibilityLabel(L10n.string("Plugin trust"))

            Button(L10n.string("Remove")) { remove(plugin) }
                .buttonStyle(.capsule(.secondary))
                .disabled(isBusy)
        }
    }

    private func trustBinding(for plugin: InstalledPlugin) -> Binding<PluginTrustLevel> {
        Binding(
            get: { plugin.trust },
            set: { level in
                Task {
                    await run {
                        try await store.setTrust(level, for: plugin.manifest.id)
                        await ToolRegistry.shared.reload()
                    }
                }
            }
        )
    }

    private func install() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.string("Choose a plugin folder containing plugin.json")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                await run {
                    let installed = try await store.install(from: url)
                    status = L10n.string("Installed \(installed.manifest.name).")
                    await ToolRegistry.shared.reload()
                    plugins = await store.installedPlugins()
                }
            }
        }
    }

    private func remove(_ plugin: InstalledPlugin) {
        Task {
            await run {
                try await store.remove(id: plugin.manifest.id)
                await ToolRegistry.shared.reload()
                status = L10n.string("Removed \(plugin.manifest.name).")
            }
        }
    }

    @MainActor
    private func reload() async {
        plugins = await store.installedPlugins()
    }

    @MainActor
    private func run(_ body: @escaping @MainActor () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await body()
            plugins = await store.installedPlugins()
        } catch {
            status = error.localizedDescription
        }
    }
}
