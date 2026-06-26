import Foundation
import Supabase

/// Supabase Auth + data access. Owns the shared client, tracks the signed-in user,
/// and exposes sign-in/up/out. Usage reporting inserts run through this client so
/// they ride the user's session (RLS: a user may only write their own rows).
@MainActor
@Observable
final class SupabaseService {
    static let shared = SupabaseService()

    let client: SupabaseClient
    private(set) var currentUser: User?
    private(set) var didLoadInitialSession = false
    var isSignedIn: Bool { currentUser != nil }

    /// Fired on every auth state transition so the window coordinator can route.
    var onAuthChange: (@MainActor (_ signedIn: Bool) -> Void)?

    private init() {
        client = SupabaseClient(supabaseURL: SupabaseConfig.url, supabaseKey: SupabaseConfig.anonKey)
    }

    /// Begin observing auth state. Emits `.initialSession` once the stored session
    /// (if any) is restored, which is how launch decides sign-in vs. home.
    func start() {
        Task { [weak self] in
            guard let self else { return }
            for await state in self.client.auth.authStateChanges {
                self.currentUser = state.session?.user
                self.didLoadInitialSession = true
                self.onAuthChange?(self.currentUser != nil)
            }
        }
    }

    var currentUserId: UUID? { currentUser?.id }

    func signIn(email: String, password: String) async throws {
        _ = try await client.auth.signIn(email: email, password: password)
    }

    func signUp(email: String, password: String) async throws {
        _ = try await client.auth.signUp(email: email, password: password)
    }

    func signOut() async {
        try? await client.auth.signOut()
    }

    // MARK: - Usage reporting

    private struct UsageInsert: Encodable {
        let user_id: String
        let device_id: String?
        let provider: String
        let model: String
        let provider_mode: String?
        let input_tokens: Int
        let output_tokens: Int
        let cache_read_tokens: Int
        let cache_write_tokens: Int
        let session_id: String?
        let app_version: String?
    }

    /// Best-effort insert of one usage record under the signed-in user's session.
    /// No-op when signed out; the local JSON cache remains the durable record.
    func reportUsage(_ r: TokenUsageRecord, deviceId: String, appVersion: String?) {
        guard let uid = currentUserId else { return }
        let row = UsageInsert(
            user_id: uid.uuidString,
            device_id: deviceId,
            provider: r.provider,
            model: r.model,
            provider_mode: r.providerMode,
            input_tokens: r.inputTokens,
            output_tokens: r.outputTokens,
            cache_read_tokens: r.cacheReadTokens,
            cache_write_tokens: r.cacheWriteTokens,
            session_id: nil,
            app_version: appVersion
        )
        // Fire-and-forget on a background task so editing/agent never waits on the network.
        let client = self.client
        Task.detached(priority: .utility) {
            do {
                try await client.from("usage_event").insert(row).execute()
            } catch {
                Log.agent.warning("usage report failed: \(error.localizedDescription)")
            }
        }
    }

    private struct PromptInsert: Encodable {
        let user_id: String
        let device_id: String?
        let session_id: String?
        let prompt: String
        let mention_count: Int
        let provider_mode: String?
        let app_version: String?
    }

    /// Best-effort capture of a user's agent prompt (beta product insight). No-op
    /// when signed out. Prompt content is sent — see privacy note in the dashboard spec.
    func reportPrompt(
        _ prompt: String,
        sessionId: String?,
        mentionCount: Int,
        providerMode: String?,
        deviceId: String,
        appVersion: String?
    ) {
        guard let uid = currentUserId else { return }
        let row = PromptInsert(
            user_id: uid.uuidString,
            device_id: deviceId,
            session_id: sessionId,
            prompt: prompt,
            mention_count: mentionCount,
            provider_mode: providerMode,
            app_version: appVersion
        )
        // Fire-and-forget on a background task so sending a prompt never waits on the network.
        let client = self.client
        Task.detached(priority: .utility) {
            do {
                try await client.from("agent_prompt").insert(row).execute()
            } catch {
                Log.agent.warning("prompt report failed: \(error.localizedDescription)")
            }
        }
    }
}
