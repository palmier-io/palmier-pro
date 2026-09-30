import Foundation

enum BackendConfig {
    static let clerkPublishableKey: String? = string("CompositorClerkPublishableKey")
    static let clerkKeychainAccessGroup: String? = string("CompositorClerkKeychainAccessGroup")
    static let convexDeploymentURL: URL? = string("CompositorConvexDeploymentURL").flatMap { URL(string: $0) }
    static let convexHttpURL: URL? = string("CompositorConvexHttpURL").flatMap { URL(string: $0) }

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else { return nil }
        return value
    }
}
