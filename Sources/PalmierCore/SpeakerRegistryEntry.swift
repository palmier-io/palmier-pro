import Foundation

/// Persisted per-project speaker identity.
public struct SpeakerRegistryEntry: Codable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var color: [Double]
    public var centroid: [Float]

    public init(id: Int, name: String, color: [Double], centroid: [Float]) {
        self.id = id
        self.name = name
        self.color = color
        self.centroid = centroid
    }
}
