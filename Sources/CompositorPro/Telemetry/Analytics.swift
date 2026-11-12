import Foundation

/// Analytics is local-only. The event taxonomy and payload builders remain so
/// instrumentation computes structured records, but nothing is enqueued or
/// transmitted.
///
/// Removed with the backend teardown (R1): previously these paths
/// shipped to PostHog when PRODUCTION_TELEMETRY was enabled.
enum Analytics {
    typealias Payload = [String: Any]

    struct Origin: Sendable {
        let source: String
        let sessionID: String
    }

    /// Attributes synchronous work started by the agent or an MCP client.
    @TaskLocal static var origin: Origin?

    static let manualSource = "manual"

    static func originProperties() -> Payload {
        guard let origin else { return ["source": manualSource] }
        return ["source": origin.source, "session_id": origin.sessionID]
    }

    static func skillReadProperties(
        skillID: String,
        skillSHA: String?,
        skillOrigin: String
    ) -> Payload {
        var properties = originProperties()
        properties["skill_id"] = skillID
        properties["skill_origin"] = skillOrigin
        if let skillSHA {
            properties["skill_sha"] = skillSHA
        }
        return properties
    }

    static func skillCreatedProperties(skillName: String) -> Payload {
        var properties = originProperties()
        properties["skill_name"] = skillName
        return properties
    }

    struct SessionActivation {
        private(set) var isActivated: Bool

        init(isActivated: Bool = false) {
            self.isActivated = isActivated
        }

        mutating func activate() -> Bool {
            guard !isActivated else { return false }
            isActivated = true
            return true
        }
    }

    enum Event: String, CaseIterable {
        case appOpened = "app opened"
        case projectCreated = "project created"
        case projectOpened = "project opened"
        case projectActive = "project active"
        case exportStarted = "export started"
        case exportFinished = "export finished"
        case exportFailed = "export failed"
        case agentSessionStarted = "agent session started"
        case agentToolCalled = "agent tool called"
        case skillCreated = "skill created"
        case skillRead = "skill read"
        case agentStarterPromptClicked = "agent starter prompt clicked"
        case editorEditCommitted = "editor edit committed"
        case generationSubmitted = "generation submitted"
        case mcpSessionActivated = "mcp session activated"
        case onboardingCompleted = "onboarding completed"
    }

    private static let enabledKey = "io.compositor.pro.analytics.enabled"

    static var isEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: enabledKey) == nil { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    static let enabledForCurrentLaunch: Bool = isEnabled

    nonisolated(unsafe) private static var activeProjectMarks: Set<String> = []
    private static let lock = NSLock()

    static var canCapture: Bool { false }

    static func start() {}

    static func identifyUser(id: String?, properties: Payload = [:]) {}

    static func resetUser() {}

    @discardableResult
    static func capture(_ event: Event, properties: Payload = [:]) -> Bool {
        false
    }

    @discardableResult
    static func captureSkillCreated(skillName: String) -> Bool {
        capture(.skillCreated, properties: skillCreatedProperties(skillName: skillName))
    }

    @discardableResult
    static func captureSkillRead(skillID: String, skillSHA: String?, skillOrigin: String) -> Bool {
        capture(
            .skillRead,
            properties: skillReadProperties(
                skillID: skillID,
                skillSHA: skillSHA,
                skillOrigin: skillOrigin
            )
        )
    }

    static func captureProjectActive(projectId: String?, properties: Payload = [:]) {
        let day = Self.dayString(Date())
        let id = projectId ?? "unknown"
        let key = "\(day):\(id)"
        lock.lock()
        let shouldCapture = activeProjectMarks.insert(key).inserted
        lock.unlock()
        guard shouldCapture else { return }
        // Local-only: marked so duplicate daily events stay deduplicated, nothing reported.
    }

    static func clean(_ value: Any) -> Any? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue
            }
            guard value.doubleValue.isFinite else { return nil }
            return value
        case let value as [String: Any]:
            var out: [String: Any] = [:]
            for (key, child) in value {
                guard let clean = clean(child) else { continue }
                out[key] = clean
            }
            return out
        case let value as [Any]:
            return value.compactMap(clean)
        default:
            return nil
        }
    }

    private static func dayString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return "unknown"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
