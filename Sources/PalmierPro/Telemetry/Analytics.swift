import Foundation
import PostHog

enum Analytics {
    typealias Payload = [String: Any]

    enum Event: String {
        case appOpened = "app opened"
        case projectCreated = "project created"
        case projectOpened = "project opened"
        case projectActive = "project active"
        case exportStarted = "export started"
        case exportFinished = "export finished"
        case exportFailed = "export failed"
        case agentSessionStarted = "agent session started"
        case agentToolCalled = "agent tool called"
        case mcpSessionStarted = "mcp session started"
    }

    private static let projectToken = Bundle.main.object(forInfoDictionaryKey: "PostHogProjectToken") as? String ?? ""
    private static let host = Bundle.main.object(forInfoDictionaryKey: "PostHogHost") as? String ?? PostHogConfig.defaultHost
    private static let enabledKey = "io.palmier.pro.analytics.enabled"

    static var isEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: enabledKey) == nil { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            guard didStart else { return }
            if newValue {
                PostHogSDK.shared.optIn()
            } else {
                PostHogSDK.shared.optOut()
            }
        }
    }

    static let enabledForCurrentLaunch: Bool = isEnabled

    nonisolated(unsafe) private static var didStart = false
    nonisolated(unsafe) private static var activeProjectMarks: Set<String> = []
    private static let lock = NSLock()

    static func start() {
        guard !didStart else { return }
        guard !projectToken.isEmpty else { return }

        let config = PostHogConfig(projectToken: projectToken, host: host)
        config.optOut = !enabledForCurrentLaunch
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.setDefaultPersonProperties = false
        config.errorTrackingConfig.autoCapture = false
        config.errorTrackingConfig.exceptionSteps.enabled = false
        config.setBeforeSend { event in
            guard Self.allowedEvents.contains(event.event) else { return nil }
            event.properties = Self.allowedProperties(for: event.event, properties: event.properties)
            return event
        }

        PostHogSDK.shared.setup(config)
        didStart = true
    }

    static func identifyUser(id: String?, properties: Payload = [:]) {
        guard didStart, isEnabled else { return }
        guard let id, !id.isEmpty else { return }
        let userProperties = cleanedCustomPayload(properties)
        PostHogSDK.shared.identify(id, userProperties: userProperties.isEmpty ? nil : userProperties)
    }

    static func resetUser() {
        guard didStart else { return }
        PostHogSDK.shared.reset()
    }

    @discardableResult
    static func capture(_ event: Event, properties: Payload = [:]) -> Bool {
        guard didStart, isEnabled else { return false }
        PostHogSDK.shared.capture(event.rawValue, properties: cleanedPayload(properties))
        return true
    }

    static func captureProjectActive(projectId: String?, properties: Payload = [:]) {
        let day = Self.dayString(Date())
        let id = projectId ?? "unknown"
        let key = "\(day):\(id)"
        lock.lock()
        let shouldCapture = activeProjectMarks.insert(key).inserted
        lock.unlock()
        guard shouldCapture else { return }
        var payload = properties
        payload["active_day"] = day
        if !capture(.projectActive, properties: payload) {
            lock.lock()
            activeProjectMarks.remove(key)
            lock.unlock()
        }
    }

    private static var allowedEvents: Set<String> {
        Set([
            Event.appOpened.rawValue,
            Event.projectCreated.rawValue,
            Event.projectOpened.rawValue,
            Event.projectActive.rawValue,
            Event.exportStarted.rawValue,
            Event.exportFinished.rawValue,
            Event.exportFailed.rawValue,
            Event.agentSessionStarted.rawValue,
            Event.agentToolCalled.rawValue,
            Event.mcpSessionStarted.rawValue,
            "$identify",
        ])
    }

    private static func cleanedPayload(_ payload: Payload) -> Payload {
        var out: Payload = [:]
        for (key, value) in payload {
            guard let clean = clean(value) else { continue }
            out[key] = clean
        }
        return out
    }

    private static func cleanedCustomPayload(_ payload: Payload) -> Payload {
        var out: Payload = [:]
        for (key, value) in payload {
            guard let clean = clean(value) else { continue }
            out[key] = clean
        }
        return out
    }

    private static func allowedProperties(for event: String, properties: Payload) -> Payload {
        if event == "$identify" {
            return allowedIdentifyProperties(properties)
        }
        let allowed = allowedCapturePropertyKeys
        return properties.reduce(into: Payload()) { out, entry in
            guard allowed.contains(entry.key), let clean = clean(entry.value) else { return }
            out[entry.key] = clean
        }
    }

    private static func allowedIdentifyProperties(_ properties: Payload) -> Payload {
        var out: Payload = [:]
        for key in ["distinct_id", "$anon_distinct_id", "$process_person_profile"] {
            guard let value = properties[key], let clean = clean(value) else { continue }
            out[key] = clean
        }
        if let set = properties["$set"] as? Payload {
            var allowedSet: Payload = [:]
            if let tier = set["tier"], let clean = clean(tier) {
                allowedSet["tier"] = clean
            }
            if !allowedSet.isEmpty {
                out["$set"] = allowedSet
            }
        }
        return out
    }

    private static var allowedCapturePropertyKeys: Set<String> {
        Set([
            "active_day",
            "export_duration_seconds",
            "failure_reason",
            "format",
            "mode",
            "model",
            "project_id",
            "resolution",
            "source",
            "status",
            "timeline_changed",
            "tool_name",
            "tool_duration_seconds",
        ])
    }

    private static func clean(_ value: Any) -> Any? {
        switch value {
        case let value as String:
            return value
        case let value as Bool:
            return value
        case let value as Int:
            return value
        case let value as Double:
            guard value.isFinite else { return nil }
            return value
        case let value as Float:
            guard value.isFinite else { return nil }
            return Double(value)
        case let value as NSNumber:
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
